function gpcf = gpcf_linear(do, varargin)
%GPCF_LINEAR	Create a linear covariance function for Gaussian Process
%
%	Description
%
%	GPCF = GPCF_LINEAR('INIT') Create and initialize linear
%       covariance function for Gaussian process
%
%	The fields and (default values) in GPCF_LINEAR are:
%	  type           = 'gpcf_linear'
%	  coeffSigma2    = Prior variances on the linear coefficients. This can be
%                      either scalar corresponding 
%                      isotropic or vector corresponding ARD. 
%                      (10)
%         p              = Prior structure for covariance function parameters. 
%                          (e.g. p.coeffSigma2.)
%         fh_pak         = function handle to pack function
%                          (@gpcf_linear_pak)
%         fh_unpak       = function handle to unpack function
%                          (@gpcf_linear_unpak)
%         fh_e           = function handle to energy function
%                          (@gpcf_linear_e)
%         fh_ghyper      = function handle to gradient of energy with respect to hyperparameters
%                          (@gpcf_linear_ghyper)
%         fh_ginput      = function handle to gradient of function with respect to inducing inputs
%                          (@gpcf_linear_ginput)
%         fh_cov         = function handle to covariance function
%                          (@gpcf_linear_cov)
%         fh_trcov       = function handle to training covariance function
%                          (@gpcf_linear_trcov)
%         fh_trvar       = function handle to training variance function
%                          (@gpcf_linear_trvar)
%         fh_recappend   = function handle to append the record function 
%                          (gpcf_linear_recappend)
%
%	GPCF = GPCF_LINEAR('SET', GPCF, 'FIELD1', VALUE1, 'FIELD2', VALUE2, ...)
%       Set the values of fields FIELD1... to the values VALUE1... in GPCF.
%       Optional field: 'selectedVariables' (uses only a selected subset of
%       variables)
%
%
%	See also
%       gpcf_exp, gpcf_matern32, gpcf_matern52, gpcf_ppcs2, gp_init, gp_e, gp_g, gp_trcov
%       gp_cov, gp_unpak, gp_pak
    
% Copyright (c) 2000-2001 Aki Vehtari
% Copyright (c) 2007-2009 Jarno Vanhatalo
% Copyright (c) 2008-2010 Jaakko Riihimaki

% This software is distributed under the GNU General Public
% License (version 2 or later); please refer to the file
% License.txt, included with the software, for details.

    if nargin < 1
        error('Not enough arguments')
    end

    % Initialize the covariance function
    if strcmp(do, 'init')
        gpcf.type = 'gpcf_linear';
        
        % Initialize parameters
        gpcf.coeffSigma2= 10;
        
        % Initialize prior structure
        gpcf.p=[];
        gpcf.p.coeffSigma2=prior_unif('init');
        
        % Set the function handles to the nested functions
        gpcf.fh_pak = @gpcf_linear_pak;
        gpcf.fh_unpak = @gpcf_linear_unpak;
        gpcf.fh_e = @gpcf_linear_e;
        gpcf.fh_ghyper = @gpcf_linear_ghyper;
        gpcf.fh_ginput = @gpcf_linear_ginput;
        gpcf.fh_cov = @gpcf_linear_cov;
        gpcf.fh_trcov  = @gpcf_linear_trcov;
        gpcf.fh_trvar  = @gpcf_linear_trvar;
        gpcf.fh_recappend = @gpcf_linear_recappend;

        if length(varargin) > 0
            if mod(nargin,2) ~=1
                error('Wrong number of arguments')
            end
            % Loop through all the parameter values that are changed
            for i=1:2:length(varargin)-1
                switch varargin{i}
                  case 'coeffSigma2'
                    gpcf.coeffSigma2 = varargin{i+1};
                  case 'fh_sampling'
                    gpcf.fh_sampling = varargin{i+1};
                  case 'coeffSigma2_prior'
                    gpcf.p.coeffSigma2 = varargin{i+1};
                  case 'selectedVariables'
                    gpcf.selectedVariables = varargin{i+1};
                    if ~sum(strcmp(varargin, 'coeffSigma2'))
                        gpcf.coeffSigma2= repmat(10, 1, length(gpcf.selectedVariables));
                    end
                  otherwise
                    error('Wrong parameter name!')
                end
            end
        end
    end

    % Set the parameter values of covariance function
    if strcmp(do, 'set')
        if mod(nargin,2) ~=0
            error('Wrong number of arguments')
        end
        gpcf = varargin{1};
        % Loop through all the parameter values that are changed
        for i=2:2:length(varargin)-1
            switch varargin{i}
              case 'coeffSigma2'
                gpcf.coeffSigma2 = varargin{i+1};
              case 'fh_sampling'
                gpcf.fh_sampling = varargin{i+1};
              case 'coeffSigma2_prior'
                gpcf.p.coeffSigma2 = varargin{i+1};
              case 'selectedVariables'
              	gpcf.selectedVariables = varargin{i+1};
              otherwise
                error('Wrong parameter name!')
            end
        end
    end

    function w = gpcf_linear_pak(gpcf, w)
    %GPCF_LINEAR_PAK	 Combine GP covariance function hyper-parameters into one vector.
    %
    %	Description
    %	W = GPCF_LINEAR_PAK(GPCF, W) takes a covariance function data structure GPCF and
    %	combines the hyper-parameters into a single row vector W.
    %
    %	The ordering of the parameters in W is:
    %       w = [gpcf.coeffSigma2 (hyperparameters of gpcf.coeffSigma2)]
    %	  
    %
    %	See also
    %	GPCF_LINEAR_UNPAK
        
        w = [];
        if ~isempty(gpcf.p.coeffSigma2)
            w = log(gpcf.coeffSigma2);
            
            % Hyperparameters of coeffSigma2
            w = [w feval(gpcf.p.coeffSigma2.fh_pak, gpcf.p.coeffSigma2)];
        end
    end

    function [gpcf, w] = gpcf_linear_unpak(gpcf, w)
    %GPCF_LINEAR_UNPAK  Separate covariance function hyper-parameter vector into components.
    %
    %	Description
    %	[GPCF, W] = GPCF_LINEAR_UNPAK(GPCF, W) takes a covariance function data structure GPCF
    %	and  a hyper-parameter vector W, and returns a covariance function data
    %	structure  identical to the input, except that the covariance hyper-parameters 
    %   has been set to the values in W. Deletes the values set to GPCF from W and returns 
    %   the modeified W. 
    %
    %	See also
    %	GPCF_LINEAR_PAK
    %
        gpp=gpcf.p;

        if ~isempty(gpp.coeffSigma2)
            i2=length(gpcf.coeffSigma2);
            i1=1;
            gpcf.coeffSigma2 = exp(w(i1:i2));
            w = w(i2+1:end);
            
            % Hyperparameters of coeffSigma2
            [p, w] = feval(gpcf.p.coeffSigma2.fh_unpak, gpcf.p.coeffSigma2, w);
            gpcf.p.coeffSigma2 = p;
        end
    end

    function eprior =gpcf_linear_e(gpcf, x, t)
    %GPCF_LINEAR_E     Evaluate the energy of prior of LINEAR parameters
    %
    %	Description
    %	E = GPCF_LINEAR_E(GPCF, X, T) takes a covariance function data structure 
    %   GPCF together with a matrix X of input vectors and a matrix T of target 
    %   vectors and evaluates log p(th) x J, where th is a vector of LINEAR parameters 
    %   and J is the Jakobian of transformation exp(w) = th. (Note that the parameters 
    %   are log transformed, when packed.)
    %
    %	See also
    %	GPCF_LINEAR_PAK, GPCF_LINEAR_UNPAK, GPCF_LINEAR_G, GP_E
    %
        [n, m] =size(x);

        % Evaluate the prior contribution to the error. The parameters that
        % are sampled are from space W = log(w) where w is all the "real" samples.
        % On the other hand errors are evaluated in the W-space so we need take
        % into account also the  Jakobian of transformation W -> w = exp(W).
        % See Gelman et.all., 2004, Bayesian data Analysis, second edition, p24.
        eprior = 0;
        gpp=gpcf.p;

        if ~isempty(gpp.coeffSigma2)
            eprior = feval(gpp.coeffSigma2.fh_e, gpcf.coeffSigma2, gpp.coeffSigma2) - sum(log(gpcf.coeffSigma2));
        end
    end

    function [DKff, gprior]  = gpcf_linear_ghyper(gpcf, x, x2, mask)  % , t, g, gdata, gprior, varargin
    %GPCF_LINEAR_GHYPER     Evaluate gradient of covariance function and hyper-prior with 
    %                     respect to the hyperparameters.
    %
    %	Description
    %	[GPRIOR, DKff, DKuu, DKuf] = GPCF_LINEAR_GHYPER(GPCF, X, T, G, GDATA, GPRIOR, VARARGIN) 
    %   takes a covariance function data structure GPCF, a matrix X of input vectors, a
    %   matrix T of target vectors and vectors GDATA and GPRIOR. Returns:
    %      GPRIOR  = d log(p(th))/dth, where th is the vector of hyperparameters 
    %      DKff    = gradients of covariance matrix Kff with respect to th (cell array with matrix elements)
    %      DKuu    = gradients of covariance matrix Kuu with respect to th (cell array with matrix elements)
    %      DKuf    = gradients of covariance matrix Kuf with respect to th (cell array with matrix elements)
    %
    %   Here f refers to latent values and u to inducing varianble (e.g. Kuf is the covariance 
    %   between u and f). See Vanhatalo and Vehtari (2007) for details.
    %
    %	See also
    %   GPCF_LINEAR_PAK, GPCF_LINEAR_UNPAK, GPCF_LINEAR_E, GP_G

        gpp=gpcf.p;
        [n, m] =size(x);

        i1=0;
        DKff = {};
        gprior = [];
        
        % Evaluate: DKff{1} = d Kff / d coeffSigma2
        % NOTE! Here we have already taken into account that the parameters are transformed
        % through log() and thus dK/dlog(p) = p * dK/dp

        
        % evaluate the gradient for training covariance
        if nargin == 2
            
            if isfield(gpcf, 'selectedVariables')
                if ~isempty(gpcf.p.coeffSigma2)
                    if length(gpcf.coeffSigma2) == 1
                        DKff{1}=gpcf.coeffSigma2*x(:,gpcf.selectedVariables)*(x(:,gpcf.selectedVariables)');
                    else
                        for i=1:length(gpcf.coeffSigma2)
                            DD = gpcf.coeffSigma2(i)*x(:,gpcf.selectedVariables(i))*(x(:,gpcf.selectedVariables(i))');
                            DD(abs(DD)<=eps) = 0;
                            DKff{i}= (DD+DD')./2;
                        end
                    end
                end
            else
                if ~isempty(gpcf.p.coeffSigma2)
                    if length(gpcf.coeffSigma2) == 1
                        DKff{1}=gpcf.coeffSigma2*x*(x');
                    else
                        for i=1:m
                            DD = gpcf.coeffSigma2(i)*x(:,i)*(x(:,i)');
                            DD(abs(DD)<=eps) = 0;
                            DKff{i}= (DD+DD')./2;
                        end
                    end
                end
            end
            
            
        % Evaluate the gradient of non-symmetric covariance (e.g. K_fu)
        elseif nargin == 3
            if size(x,2) ~= size(x2,2)
                error('gpcf_linear -> _ghyper: The number of columns in x and x2 has to be the same. ')
            end

            if isfield(gpcf, 'selectedVariables')
                if ~isempty(gpcf.p.coeffSigma2)
                    if length(gpcf.coeffSigma2) == 1
                        DKff{1}=gpcf.coeffSigma2*x(:,gpcf.selectedVariables)*(x2(:,gpcf.selectedVariables)');
                    else
                        for i=1:length(gpcf.coeffSigma2)
                            DKff{i}=gpcf.coeffSigma2(i)*x(:,gpcf.selectedVariables(i))*(x2(:,gpcf.selectedVariables(i))');
                        end
                    end
                end
            else
                if ~isempty(gpcf.p.coeffSigma2)
                    if length(gpcf.coeffSigma2) == 1
                        DKff{1}=gpcf.coeffSigma2*x*(x2');
                    else
                        for i=1:m
                            DKff{i}=gpcf.coeffSigma2(i)*x(:,i)*(x2(:,i)');
                        end
                    end
                end
            end
            % Evaluate: DKff{1}    = d mask(Kff,I) / d constSigma2
            %           DKff{2...} = d mask(Kff,I) / d coeffSigma2
        elseif nargin == 4
            
            if isfield(gpcf, 'selectedVariables')
                if ~isempty(gpcf.p.coeffSigma2)
                    if length(gpcf.coeffSigma2) == 1
                        DKff{1}=gpcf.coeffSigma2*sum(x(:,gpcf.selectedVariables).^2,2); % d mask(Kff,I) / d coeffSigma2
                    else
                        for i=1:length(gpcf.coeffSigma2)
                            DKff{i}=gpcf.coeffSigma2(i)*(x(:,gpcf.selectedVariables(i)).^2); % d mask(Kff,I) / d coeffSigma2
                        end
                    end
                end
            else
                if ~isempty(gpcf.p.coeffSigma2)
                    if length(gpcf.coeffSigma2) == 1
                        DKff{1}=gpcf.coeffSigma2*sum(x.^2,2); % d mask(Kff,I) / d coeffSigma2
                    else
                        for i=1:m
                            DKff{i}=gpcf.coeffSigma2(i)*(x(:,i).^2); % d mask(Kff,I) / d coeffSigma2
                        end
                    end
                end
            end
        end
        
        if nargout > 1
            
            if ~isempty(gpcf.p.coeffSigma2)
                lll = length(gpcf.coeffSigma2);
                gg = feval(gpp.coeffSigma2.fh_g, gpcf.coeffSigma2, gpp.coeffSigma2);
                gprior = gg(1:lll).*gpcf.coeffSigma2 - 1;
                gprior = [gprior gg(lll+1:end)];
            end
        end
    end


    function [DKff, gprior]  = gpcf_linear_ginput(gpcf, x, x2)
    %GPCF_LINEAR_GIND     Evaluate gradient of covariance function with 
    %                   respect to x.
    %
    %	Description
    %	[GPRIOR_IND, DKuu, DKuf] = GPCF_LINEAR_GIND(GPCF, X, T, G, GDATA_IND, GPRIOR_IND, VARARGIN) 
    %   takes a covariance function data structure GPCF, a matrix X of input vectors, a
    %   matrix T of target vectors and vectors GDATA_IND and GPRIOR_IND. Returns:
    %      GPRIOR  = d log(p(th))/dth, where th is the vector of hyperparameters 
    %      DKuu    = gradients of covariance matrix Kuu with respect to Xu (cell array with matrix elements)
    %      DKuf    = gradients of covariance matrix Kuf with respect to Xu (cell array with matrix elements)
    %
    %   Here f refers to latent values and u to inducing varianble (e.g. Kuf is the covariance 
    %   between u and f). See Vanhatalo and Vehtari (2007) for details.
    %
    %	See also
    %   GPCF_LINEAR_PAK, GPCF_LINEAR_UNPAK, GPCF_LINEAR_E, GP_G
        
        [n, m] =size(x);
        
        if nargin == 2
            
            %K = feval(gpcf.fh_trcov, gpcf, x);
            
            if length(gpcf.coeffSigma2) == 1
                % In the case of an isotropic LINEAR
                s = repmat(gpcf.coeffSigma2, 1, m);
            else
                s = gpcf.coeffSigma2;
            end
            
            ii1 = 0;
            if isfield(gpcf, 'selectedVariables')
                for i=1:length(gpcf.selectedVariables)
                    for j = 1:n
                        
                        DK = zeros(n);
                        DK(j,:)=s(i)*x(:,gpcf.selectedVariables(i))';
                        
                        DK = DK + DK';
                        
                        ii1 = ii1 + 1;
                        DKff{ii1} = DK;
                        gprior(ii1) = 0;
                    end
                end
            else
                for i=1:m
                    for j = 1:n
                        
                        DK = zeros(n);
                        DK(j,:)=s(i)*x(:,i)';
                        
                        DK = DK + DK';
                        
                        ii1 = ii1 + 1;
                        DKff{ii1} = DK;
                        gprior(ii1) = 0;
                    end
                end
            end
            
            
            
        elseif nargin == 3
            %K = feval(gpcf.fh_cov, gpcf, x, x2);
            
            if length(gpcf.coeffSigma2) == 1
                % In the case of an isotropic LINEAR
                s = repmat(gpcf.coeffSigma2, 1, m);
            else
                s = gpcf.coeffSigma2;
            end
            
            ii1 = 0;
            if isfield(gpcf, 'selectedVariables')
                for i=1:length(gpcf.selectedVariables)
                    for j = 1:n
                        
                        DK = zeros(n, size(x2,1));
                        DK(j,:)=s(i)*x2(:,gpcf.selectedVariables(i))';
                        
                        ii1 = ii1 + 1;
                        DKff{ii1} = DK;
                        gprior(ii1) = 0;
                    end
                end
            else
                for i=1:m
                    for j = 1:n
                        
                        DK = zeros(n, size(x2,1));
                        DK(j,:)=s(i)*x2(:,i)';
                        
                        ii1 = ii1 + 1;
                        DKff{ii1} = DK;
                        gprior(ii1) = 0;
                    end
                end
            end
            
        end
    end


    function C = gpcf_linear_cov(gpcf, x1, x2, varargin)
    % GP_LINEAR_COV     Evaluate covariance matrix between two input vectors.
    %
    %         Description
    %         C = GP_LINEAR_COV(GP, TX, X) takes in covariance function of a Gaussian
    %         process GP and two matrixes TX and X that contain input vectors to
    %         GP. Returns covariance matrix C. Every element ij of C contains
    %         covariance between inputs i in TX and j in X.
    %
    %
    %         See also
    %         GPCF_LINEAR_TRCOV, GPCF_LINEAR_TRVAR, GP_COV, GP_TRCOV
        
        if isempty(x2)
            x2=x1;
        end
        [n1,m1]=size(x1);
        [n2,m2]=size(x2);

        if m1~=m2
            error('the number of columns of X1 and X2 has to be same')
        end
        
        if isfield(gpcf, 'selectedVariables')
            C = x1(:,gpcf.selectedVariables)*diag(gpcf.coeffSigma2)*(x2(:,gpcf.selectedVariables)');
        else
            C = x1*diag(gpcf.coeffSigma2)*(x2');
        end
        C(abs(C)<=eps) = 0;
    end

    function C = gpcf_linear_trcov(gpcf, x)
    % GP_LINEAR_TRCOV     Evaluate training covariance matrix of inputs.
    %
    %         Description
    %         C = GP_LINEAR_TRCOV(GP, TX) takes in covariance function of a Gaussian
    %         process GP and matrix TX that contains training input vectors. 
    %         Returns covariance matrix C. Every element ij of C contains covariance 
    %         between inputs i and j in TX
    %
    %
    %         See also
    %         GPCF_LINEAR_COV, GPCF_LINEAR_TRVAR, GP_COV, GP_TRCOV

        if isfield(gpcf, 'selectedVariables')
            C = x(:,gpcf.selectedVariables)*diag(gpcf.coeffSigma2)*(x(:,gpcf.selectedVariables)');
        else
            C = x*diag(gpcf.coeffSigma2)*(x');
        end
        C(abs(C)<=eps) = 0;
        C = (C+C')./2;

    end


    function C = gpcf_linear_trvar(gpcf, x)
    % GP_LINEAR_TRVAR     Evaluate training variance vector
    %
    %         Description
    %         C = GP_LINEAR_TRVAR(GPCF, TX) takes in covariance function of a Gaussian
    %         process GPCF and matrix TX that contains training inputs. Returns variance 
    %         vector C. Every element i of C contains variance of input i in TX
    %
    %
    %         See also
    %         GPCF_LINEAR_COV, GPCF_LINEAR_COVVEC, GP_COV, GP_TRCOV
                

        if length(gpcf.coeffSigma2) == 1
            if isfield(gpcf, 'selectedVariables')
                C=gpcf.coeffSigma2.*sum(x(:,gpcf.selectedVariables).^2,2);
            else
                C=gpcf.coeffSigma2.*sum(x.^2,2);
            end
        else
            if isfield(gpcf, 'selectedVariables')
                C=sum(repmat(gpcf.coeffSigma2, size(x,1), 1).*x(:,gpcf.selectedVariables).^2,2);
            else
                C=sum(repmat(gpcf.coeffSigma2, size(x,1), 1).*x.^2,2);
            end
        end
        C(abs(C)<eps)=0;
  
    end

    function reccf = gpcf_linear_recappend(reccf, ri, gpcf)
    % RECAPPEND - Record append
    %          Description
    %          RECCF = GPCF_LINEAR_RECAPPEND(RECCF, RI, GPCF) takes old covariance
    %          function record RECCF, record index RI and covariance function structure. 
    %          Appends the parameters of GPCF to the RECCF in the ri'th place.
    %
    %          RECAPPEND returns a structure RECCF containing following record fields:
    %          lengthHyper    
    %          lengthHyperNu  
    %          coeffSigma2    
    %
    %          See also
    %          GP_MC and GP_MC -> RECAPPEND

    % Initialize record
        if nargin == 2
            reccf.type = 'gpcf_linear';

            % Initialize parameters
            reccf.coeffSigma2= [];

            % Set the function handles
            reccf.fh_pak = @gpcf_linear_pak;
            reccf.fh_unpak = @gpcf_linear_unpak;
            reccf.fh_e = @gpcf_linear_e;
            reccf.fh_g = @gpcf_linear_g;
            reccf.fh_cov = @gpcf_linear_cov;
            reccf.fh_trcov  = @gpcf_linear_trcov;
            reccf.fh_trvar  = @gpcf_linear_trvar;
            reccf.fh_recappend = @gpcf_linear_recappend;
            gpcf.p=[];
            gpcf.p.coeffSigma2=[];
            if ~isempty(ri.p.coeffSigma2)
                reccf.p.coeffSigma2 = ri.p.coeffSigma2;
            end

            return
        end

        gpp = gpcf.p;
        % record coeffSigma2
        if ~isempty(gpcf.coeffSigma2)
            reccf.coeffSigma2(ri,:)=gpcf.coeffSigma2;
            reccf.p.coeffSigma2 = feval(gpp.coeffSigma2.fh_recappend, reccf.p.coeffSigma2, ri, gpcf.p.coeffSigma2);
        elseif ri==1
            reccf.coeffSigma2=[];
        end
        
        if isfield(gpcf, 'selectedVariables')
        	reccf.selectedVariables = gpcf.selectedVariables;
        end
        
    end
end